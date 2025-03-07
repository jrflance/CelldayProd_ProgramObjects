--liquibase formatted sql

--changeset MHoward:0D5555 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
--==============================================================================
--            : 
--     Author : Brandon Stahl
--            : 
--    Created : 2019-01-04
--            : 
--Description : This Sproc reconciles Network_IP confirmations and compares them  
--            : against T-Cetra orders to preemptively catch bill discrepancies.  
--            :
--            :
--      Usage : EXEC [Report].[P_Report_Accounting_Network_IPConfirmationRecon]
--            : 
-- MH20190826 : Moved ISNULL(o.ParentItem_ID) = 0 to be paired with OrderType_ID to only check ParentItem_ID when OrderType_ID is 22 or 23 and change allow OrderType_ID 0 and 1.
--			  :
-- MR20200317 : Added VendorDiscrepancy insert logic and Cast TransactionDate to Date
--			  :
-- MR20200324 : Switched "UserName" to Char11 rather than Char10
--			  :
-- MH20210921 : Fixed issue with discrepancy insert Join
--			  :
-- MH20210922 : Updated Discrepancy insert to use NetCharges - Tcetra cost for Discrepancy Amount
--	   	      :		for Billed Incorrect Amount
--			  :
-- MH20240215 : Removed ParentItemID filter for excluding Spiffs to accomidate Activation Fee
-- MH20240215 : Update to new mapping logic
--================================================================================
-- noqa: enable=all
CREATE OR ALTER PROCEDURE [Report].[P_Report_Accounting_Network_IPConfirmationRecon]
AS
BEGIN
    SET NOCOUNT ON;

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    BEGIN TRY
        DECLARE
            @Delimeter CHAR(1) = '|',
            @MedianDate DATETIME,
            @N INT;

        IF OBJECT_ID('tempdb..#NetworkIPBill') IS NOT NULL
            BEGIN
                DROP TABLE #NetworkIPBill;
            END;

        SELECT
            B.Chr1 AS [TransactionDate],
            B.Chr2 AS [Pin],
            B.Chr3 AS [BillingType],
            B.Chr4 AS [BillingCustomer],
            B.Chr5 AS [TotalDiscountAmt],
            B.Chr6 AS [AverageDiscount],
            B.Chr7 AS [TotalRetailAmt],
            B.Chr8 AS [TransactionCount],
            B.Chr9 AS [TotalBilledAmt],
            B.Chr11 AS [UserName]
        INTO #NetworkIPBill
        FROM Recon.tblPlainText AS A
        CROSS APPLY dbo.SplitText(A.PlainText, @Delimeter, '"') AS B
        WHERE TRY_CONVERT(DATETIME, B.Chr1) IS NOT NULL;

        IF OBJECT_ID('tempdb..#Dates') IS NOT NULL
            BEGIN
                DROP TABLE #Dates;
            END;

        SELECT
            ROW_NUMBER() OVER (
                PARTITION BY
                1
                ORDER BY
                    CAST(TransactionDate AS DATE)
            ) AS Rnum,
            CAST(TransactionDate AS DATE) AS TransactionDate
        INTO #Dates
        FROM #NetworkIPBill AS nib
        GROUP BY
            CAST(TransactionDate AS DATE);

        SET @N = (SELECT MAX(Rnum) FROM #Dates);

        IF (@N <> 0 AND (@N % 2) = 0)
            BEGIN
                SELECT
                    @MedianDate = d.TransactionDate
                FROM
                    #Dates AS d
                WHERE
                    d.Rnum = (@N / 2);
            END;
        ELSE IF (@N <> 0 AND (@N % 2) <> 0)
            BEGIN
                SELECT
                    @MedianDate = d.TransactionDate
                FROM
                    #Dates AS d
                WHERE
                    d.Rnum = ((@N + 1) / 2);
            END;
        ELSE
            BEGIN
                SELECT
                    'Invalid Date Range!';

                RETURN;
            END;

        IF OBJECT_ID('tempdb..#TCetraFilled') IS NOT NULL
            BEGIN
                DROP TABLE #TCetraFilled;
            END;

        SELECT
            ROW_NUMBER() OVER (
                PARTITION BY nib.Pin
                ORDER BY ABS(DATEDIFF(DAY, n.DateFilled, nib.TransactionDate))
            ) AS Rnum,
            n.Order_No,
            n.DateFilled,
            n.Filled,
            o.Product_ID,
            o.Name,
            o.Price,
            o.ID,
            p.Product_Type,
            nib.Pin,
            n.OrderType_ID --MH20240215
        INTO #TCetraFilled
        FROM dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.tblOrderItemAddons AS oia
            ON oia.OrderID = o.ID
        JOIN dbo.tblAddonFamily AS af
            ON af.AddonID = oia.AddonsID
        JOIN #NetworkIPBill AS nib
            ON nib.Pin = oia.AddonsValue
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID AND ISNULL(p.Product_Type, 0) IN (0, 1, 2, 3) --MH20240215
        JOIN Products.tblProductCarrierMapping AS pcm
            ON pcm.ProductId = o.Product_ID
        WHERE
            n.Void = 0
            --AND											--MH20240215 (removed)
            --(
            --    (
            --        n.OrderType_ID IN ( 22, 23 )
            --        AND o.ParentItemID IN ( 0, 1 )
            --    )
            --    OR n.OrderType_ID IN ( 1, 9 )
            --) --MH20190826
            AND n.OrderType_ID IN (1, 9, 22, 23) --MH20240215
            AND CAST(n.DateFilled AS DATE) >= DATEADD(DAY, -2 * @N, @MedianDate)
            AND CAST(n.DateFilled AS DATE) < DATEADD(DAY, 2 * @N, @MedianDate)
            AND af.AddonTypeName = CASE
                WHEN
                    n.OrderType_ID IN (22, 23) AND NOT EXISTS
                    (
                        SELECT
                            1
                        FROM
                            CellDay_Prod.dbo.tblOrderItemAddons AS oia
                        JOIN CellDay_Prod.dbo.tblAddonFamily AS af
                            ON oia.AddonsID = af.AddonID
                        WHERE
                            af.AddonTypeName = 'PortInType'
                            AND oia.OrderID = o.ID
                    )
                    THEN 'ReturnPhoneType'
                ELSE 'PhoneNumberType'
            END
            --AND ISNULL(o.ParentItemID, 0)  = 0	MH20190826
            AND pcm.CarrierId = 250;

        --M20240215 (removed to replace with new mapping logic below)
        --IF OBJECT_ID('tempdb..#logData') IS NOT NULL
        --BEGIN
        --    DROP TABLE #logData;
        --END;

        --SELECT ot.Order_No,
        --       ot.Product_ID,
        --       MIN(lvpm.ID) AS [MinLogId]
        --INTO #logData
        --FROM #TCetraFilled ot
        --    JOIN [Logs].[VendorProductMapping] lvpm
        --        ON CAST(lvpm.ProductIdBefore AS VARCHAR(10)) = ot.Product_ID
        --           AND ot.DateFilled < lvpm.LogDate
        --           AND NOT EXISTS
        --                   (
        --                       SELECT 1
        --                       FROM dbo.Order_Activation_User_Lock oaul
        --                       WHERE oaul.Order_No = ot.Order_No
        --                   )
        --           AND lvpm.RegiondIdBefore = CASE
        --                                          WHEN EXISTS
        --                                               (
        --                                                   SELECT 1
        --                                                   FROM dbo.tblOrderItemAddons oia
        --                                                   WHERE oia.OrderID = ot.ID
        --                                                         AND oia.AddonsID = 26
        --                                               )
        --                                               AND EXISTS
        --                                                   (
        --                                                       SELECT 1
        --                                                       FROM [Logs].[VendorProductMapping] lvpm2
        --                                                       WHERE lvpm2.RegiondIdBefore = 4
        --                                                             AND ot.DateFilled < lvpm2.LogDate
        --                                                             AND lvpm2.VendorSkuBefore IS NOT NULL
        --                                                             AND CAST(lvpm2.ProductIdBefore AS VARCHAR(10)) = ot.Product_ID
        --                                                   ) THEN
        --                                              4
        --                                          ELSE
        --                                              1
        --                                      END
        --GROUP BY ot.Order_No,
        --         ot.Product_ID;

        --IF OBJECT_ID('tempdb..#VendorData') IS NOT NULL
        --BEGIN
        --    DROP TABLE #VendorData;
        --END;

        --SELECT DISTINCT
        --       ot.Order_No,
        --       ot.Product_ID,
        --       vpm.Region_ID,
        --       CASE
        --           WHEN EXISTS
        --                (
        --                    SELECT 1
        --                    FROM dbo.Order_Activation_User_Lock oaul
        --                    WHERE oaul.Order_No = ot.Order_No
        --                ) THEN
        --               ISNULL(p.Vendor1_SKU, ISNULL(CAST(vpm.Vendor_SKU AS VARCHAR(10)), ot.Product_ID))
        --           ELSE
        --               ISNULL(CAST(vpm.Vendor_SKU AS VARCHAR(10)), ot.Product_ID)
        --       END AS [VendorSku],
        --       vpm.Vendor_SKU AS vpmVendor_SKU
        --INTO #VendorData
        --FROM #TCetraFilled ot
        --    JOIN dbo.Products AS p
        --        ON p.Product_ID = ot.Product_ID
        --    JOIN dbo.Vendor_Product_Mapping vpm
        --        ON CAST(vpm.Product_ID AS VARCHAR(10)) = ot.Product_ID
        --           AND vpm.Region_ID = CASE
        --                                   WHEN EXISTS
        --                                        (
        --                                            SELECT 1
        --                                            FROM dbo.tblOrderItemAddons oia
        --                                            WHERE oia.OrderID = ot.ID
        --                                                  AND oia.AddonsID = 26
        --                                        )
        --                                        AND EXISTS
        --                                            (
        --                                                SELECT 1
        --                                                FROM dbo.Vendor_Product_Mapping vpm2
        --                                                WHERE vpm2.Region_ID = 4
        --                                                      AND vpm2.Vendor_SKU IS NOT NULL
        --                                                      AND CAST(vpm2.Product_ID AS VARCHAR(10)) = ot.Product_ID
        --                                            ) THEN
        --                                       4
        --                                   ELSE
        --                                       1
        --                               END;
        IF OBJECT_ID('tempdb..#Duplicates') IS NOT NULL
            BEGIN
                DROP TABLE #Duplicates;
            END;

        SELECT
            tcf.Pin,
            COUNT(1) AS Qty
        INTO #Duplicates
        FROM #TCetraFilled AS tcf
        WHERE
            tcf.Rnum = 1
        GROUP BY
            tcf.Pin
        HAVING
            COUNT(1) > 1;

        IF OBJECT_ID('tempdb..#Results') IS NOT NULL
            BEGIN
                DROP TABLE #Results;
            END;

        SELECT
            CAST(nib.TransactionDate AS DATE) AS TransactionDate,
            nib.Pin,
            nib.BillingType,
            nib.BillingCustomer,
            nib.TotalDiscountAmt,
            nib.AverageDiscount,
            nib.TotalRetailAmt,
            nib.TransactionCount,
            nib.TotalBilledAmt,
            tcf.Order_No,
            tcf.DateFilled,
            p.Product_ID,
            tcf.Name,
            tcf.Price,
            dcp.Percent_Amount_Flg,
            dcp.Discount_Amt,
            CASE
                WHEN dcp.Percent_Amount_Flg = 'P'
                    THEN tcf.Price - tcf.Price * dcp.Discount_Amt / 100
                WHEN dcp.Percent_Amount_Flg = 'A'
                    THEN tcf.Price - tcf.Price - dcp.Discount_Amt
                ELSE 0
            END AS AmountDue,
            CASE
                WHEN EXISTS (SELECT 1 FROM #Duplicates AS d WHERE d.Pin = nib.Pin)
                    THEN 'Duplicate'
                WHEN tcf.Order_No IS NULL
                    THEN 'Exception'
                WHEN (
                    nib.TotalBilledAmt -
                    CASE
                        WHEN dcp.Percent_Amount_Flg = 'P'
                            THEN tcf.Price - tcf.Price * dcp.Discount_Amt / 100
                        WHEN dcp.Percent_Amount_Flg = 'A'
                            THEN tcf.Price - tcf.Price - dcp.Discount_Amt
                        ELSE 0
                    END
                ) <> 0
                    THEN 'Billed Incorrect Amount'
                ELSE 'Success'
            END AS [Status],
            nib.UserName
        INTO #Results
        FROM #NetworkIPBill AS nib
        LEFT JOIN #TCetraFilled AS tcf
            ON nib.Pin = tcf.Pin AND tcf.Rnum = 1
        LEFT JOIN dbo.Products AS p2 --MH20240215
            ON tcf.Product_ID = p2.Product_ID
        LEFT JOIN Orders.tblOrderVendorDetails AS vd
            ON otcfID = vd.OrderId AND tcf.OrderType_ID IN (22, 23) -- noqa: RF02
        LEFT JOIN dbo.Vendor_Product_Mapping AS vpm
            ON
                tcf.Product_ID = vpm.Product_ID
                AND vpm.Region_ID = 1
                AND tcf.OrderType_ID IN (22, 23)
        JOIN dbo.Products AS p
            ON
                CASE
                    WHEN tcf.OrderType_ID IN (22, 23) AND p2.Product_Type = 3
                        THEN ISNULL(ISNULL(vd.FundingProductID, vpm.Vendor_SKU), tcf.Product_ID)
                    ELSE tcf.Product_ID
                END = p.Product_ID
        LEFT JOIN dbo.DiscountClass_Products AS dcp --MH20240215
            ON dcp.Product_ID = p.Product_ID AND dcp.DiscountClass_ID = 10;

        --LEFT JOIN #logData t							--MH20240215 (removed)
        --    ON t.Order_No = tcf.Order_No
        --LEFT JOIN #VendorData AS vd
        --    ON vd.Order_No = tcf.Order_No
        --LEFT JOIN [Logs].[VendorProductMapping] tvpm
        --    ON tvpm.ID = t.[MinLogId]
        --LEFT JOIN dbo.DiscountClass_Products AS dcp					--MH20240215 (removed)
        --    ON dcp.Product_ID = CASE
        --                            WHEN ISNULL(tcf.Product_Type, 0) = 3 THEN
        --                                ISNULL(
        --                                          ISNULL(
        --                                                    CAST(tvpm.VendorSkuBefore AS VARCHAR(10)),
        --                                                    CAST(vd.VendorSku AS VARCHAR(10))
        --                                                ),
        --                                          tcf.Product_ID
        --                                      )
        --                            ELSE
        --                                tcf.Product_ID
        --                        END
        --       AND dcp.DiscountClass_ID = 10;
        TRUNCATE TABLE CellDayTemp.Recon.tblNetwork_IPConfirmationReconResult;

        INSERT INTO CellDayTemp.Recon.tblNetwork_IPConfirmationReconResult
        (
            TransactionDate,
            Pin,
            BillingType,
            BillingCustomer,
            TotalDiscountAmt,
            AverageDiscount,
            TotalRetailAmt,
            TransactionCount,
            TotalBilledAmt,
            Order_No,
            DateFilled,
            Product_ID,
            Name,
            Price,
            Percent_Amount_Flg,
            Discount_Amt,
            AmountDue,
            Status
        )
        SELECT
            TransactionDate,
            Pin,
            BillingType,
            BillingCustomer,
            TotalDiscountAmt,
            AverageDiscount,
            TotalRetailAmt,
            TransactionCount,
            TotalBilledAmt,
            Order_No,
            DateFilled,
            Product_ID,
            Name,
            Price,
            Percent_Amount_Flg,
            Discount_Amt,
            AmountDue,
            [Status]
        FROM #Results;

        IF OBJECT_ID('tempdb..#MaxDateInsertPrep') IS NOT NULL
            BEGIN
                DROP TABLE #MaxDateInsertPrep;
            END;

        SELECT DISTINCT -- noqa: AM01
            CONCAT(YEAR(r.TransactionDate), MONTH(r.TransactionDate), DAY(r.TransactionDate), 'NETWORK_IP') AS InvoiceNo,
            MAX(r.TransactionDate) AS InvoiceDate,
            6 AS Process_ID -- Network IP
        INTO #MaxDateInsertPrep
        FROM #Results AS r
        GROUP BY
            r.TransactionDate;

        INSERT INTO Cellday_Accounting.acct.VendorInvoice --MR20190711
        (
            InvoiceNo,
            InvoiceDate,
            Process_Id
        )
        SELECT
            MAX(m.InvoiceNo) AS InvoiceNo,
            MAX(m.InvoiceDate) AS InvoiceDate,
            m.Process_ID -- Network IP
        FROM
            #MaxDateInsertPrep AS m
        GROUP BY
            m.Process_ID;

        INSERT INTO Cellday_Accounting.acct.VendorDiscrepancies --MR20190711
        (
            Process_Id,
            DateCreated,
            UserCreated,
            Discrepancy_ID,
            DiscrepancyAmt,
            TransactionID,
            Order_No,
            VendorInvoice_ID
        )
        SELECT
            6 AS process_ID, --Network IP
            GETDATE() AS DateCreated,
            r.UserName AS UserCreated,
            CASE
                WHEN r.Status = 'Missing'
                    THEN 14
                WHEN r.Status = 'Duplicate'
                    THEN 16
                WHEN r.Status = 'Billed Incorrect Amount'
                    THEN 15
                ELSE 11
            END AS Discrepancy_ID,
            --r.Price AS DiscrepancyAmt,													--MH20210922
            CASE
                WHEN r.Status = 'Billed Incorrect Amount'
                    THEN r.TotalBilledAmt - r.AmountDue
                ELSE r.TotalBilledAmt
            END AS DiscrepancyAmt,
            r.PIN AS TransactionID,
            r.Order_No AS Order_NO,
            vi.ID AS VendorInvoice_ID
        FROM
            #Results AS r
        JOIN Cellday_Accounting.acct.VendorInvoice AS vi
            --ON vi.InvoiceDate = r.TransactionDate										--MH20210921
            ON
                vi.InvoiceDate =
                (
                    SELECT MAX(InvoiceDate) FROM #MaxDateInsertPrep
                ) --MH20210921
                AND vi.Process_Id = 6 --Network IP
        WHERE
            r.Status <> 'Success';
    END TRY
    BEGIN CATCH
    ; THROW;
    END CATCH;
END
-- noqa: disable=all
/