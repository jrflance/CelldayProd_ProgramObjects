--liquibase formatted sql

--changeset melissarios:2131091 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
/* =============================================
             :
      Author : Jacob Lowe
             :
     Created : 2018-04-16
 Description : Pay out Xfinity Spiff
             :
    Modified :
          SB : 2021-07-07  Added logic to check if instant spiff paid previously and refined the previously paid retro spiff check to do auth combined with sku
		  SB : 2021-07-14 Commented out status 10 check due to excessive processing time
         djj : 2022-01-25 Add logic to leave one record where duplicate values exists
		  MR : 2023-04-28 Modified for the new csv file data:
			 :			  Removed Device Serial number.
			 :			  Changed product ID payout from 10359 to 11576,
			 :			  Brought in Merchant Amount from billing tables rather than calculating it here.
             : MR20230609 Changed back to product ID 10359. Note it has to be changed at line ~140
							And in [Billing].[tblBPProductMapping] (see INTO #Payout section).
						  Added a new INSERT INTO #OrdersWithAmounts section for Merchant Amounts less than 0.00 and limited the first one to Merchant Amounts greater than 0.00
							And changed the second insert to take the "ABS(t.MerchantAmount)" so that chargeback commission were calculated correctly.
						 Adjusted the logic to leave one record where duplicate values exist.
						 Added the MerchantAmount column into the #MultipleProcessing section to not exclude chargebacks.
						 Added a second "Previously Processed" Status ID of 4 section to check for file ID 2583 where SKUs were not populated.
						 Added both email sending sections.
						 Added #SummedPayout and #SummedCommissions.
						 Added in the OrderManagment.tblXfinityActivationReporting section.
						 Added Mac_ID join in the insert into Order_Commission table.
						 Added multiple columns throughout for reporting or joining purposes.
			 : MR20240307 Changing the table OrderManagment.tblXfinityActivationReporting to retain up to 36 months.
						  Wrapping the SUM(c.xfinityAmount) with an "ISNULL" in the email.
						  Adding an error section for "Not Reported by Xfinity"
 =============================================*/
 -- noqa: enable=all
ALTER PROCEDURE [Billing].[P_ProcessingXfinitySpiff]
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    BEGIN TRY

        DECLARE @getdate DATETIME = GETDATE();

        DECLARE @BPProcessTypeID TABLE (ID INT);

        -- Get the ID for Xfinity Spiff - 18
        INSERT INTO @BPProcessTypeID (ID)
        SELECT BPProcessTypeID
        FROM Billing.tblBPProcessType
        WHERE Sproc = 'P_ProcessingXfinitySpiff';

        -----------------------------------------------------------------------------------------------------------

        IF OBJECT_ID('tempdb..#PivotData') IS NOT NULL
            BEGIN
                DROP TABLE #PivotData;
            END;
        WITH
        CTE AS (
            SELECT
                bp.BillingPaymentID
                , bp.ParentCompanyID
                , bpd.DataType
                , bpd.Data
                , bp.MerchantAmount
                , bp.TransactionDate			--added MR20230609
                , bp.FileID						--added MR20230609
            FROM [Billing].[tblBillingPayments] AS bp
            JOIN [Billing].[tblBPDataMapping] AS bpdm
                ON bpdm.BillingPaymentID = bp.BillingPaymentID
            JOIN [Billing].[tblBPData] AS bpd
                ON bpd.BPDataID = bpdm.BPDataID
            JOIN @BPProcessTypeID AS bppt
                ON bp.BPProcessTypeID = bppt.ID
            WHERE bp.BPStatusID = 0
        )
        -- pivot to have one record per BillingPaymentID
        SELECT
            piv.BillingPaymentID
            , piv.ParentCompanyID
            , piv.MAC_ID
            , piv.MerchantAmount
            , piv.TransactionDate
            , piv.FileID
        INTO #PivotData
        FROM CTE
        PIVOT
        (
            MAX([Data])
            FOR DataType IN
            (MAC_ID)
        ) piv;
        --If same datatype exists on the same BPID, it will only select max

        IF EXISTS (SELECT 1 FROM #PivotData AS pd)
            BEGIN
                DECLARE
                    @StartDate DATETIME
                    = (SELECT CONCAT(YEAR(MAX(pd.TransactionDate)), '-', MONTH(MAX(pd.TransactionDate)), '-', '01') FROM #PivotData AS pd)
                DECLARE @EndDate DATETIME = (SELECT DATEADD(DAY, 1, MAX(pd.TransactionDate)) FROM #PivotData AS pd)
            END;

        DELETE FROM OrderManagment.tblXfinityActivationReporting WHERE DateUpdated <= DATEADD(M, -36, GETDATE()) --changing to 36 months MR20240307

        INSERT INTO OrderManagment.tblXfinityActivationReporting
        (
            ActivationOrderNo,
            TCETRASpiffAmount,
            MAC_ID,
            DateUpdated,
            UserUpdated
        )
        SELECT
            n.order_NO AS ActivationOrderNo,
            d.price AS TCETRASpiffAmount,
            SUBSTRING(
                CAST(d.Addons AS NVARCHAR(MAX)),
                PATINDEX('%MAC Address:%', CAST(d.Addons AS NVARCHAR(MAX))) + 12,
                (PATINDEX('%<br>%', CAST(d.Addons AS NVARCHAR(MAX))) - 8
                )
            )
                AS [MAC_ID],
            GETDATE() AS DateUpdated,
            'XfinityProcessing' AS UserUpdated
        FROM dbo.orders AS d
        JOIN dbo.order_No AS n
            ON
                n.Order_No = d.Order_No
                AND n.Filled = 1
                AND n.Void = 0
                AND n.Process = 1
                AND n.OrderType_ID IN (22, 23)
                AND n.DateFilled >= @StartDate
        WHERE
            d.Product_ID = 11576		--instant spiff
            AND ISNULL(d.ParentItemID, 0) NOT IN (0, 1)
            AND d.Price < 0.00
            AND NOT EXISTS (
                SELECT 1 FROM OrderManagment.tblXfinityActivationReporting AS x
                WHERE x.ActivationOrderNo = n.Order_No
            )

        UPDATE p
        SET
            p.ActivationDateReportedFromXfinity = pd.TransactionDate,
            p.XfinityFileID = pd.fileID,
            p.XfinityAmount = (pd.MerchantAmount * -1)
        --SELECT *
        FROM OrderManagment.tblXfinityActivationReporting AS p
        JOIN #PivotData AS pd
            ON
                p.MAC_ID = pd.MAC_ID
                AND pd.MerchantAmount > 0

        UPDATE p
        SET
            p.XfinityChargebackDate = pd.TransactionDate,
            p.XfinityChargebackFileID = pd.fileID,
            p.XfinityChargebackAmount = (pd.MerchantAmount * -1)
        --SELECT *
        FROM OrderManagment.tblXfinityActivationReporting AS p
        JOIN #PivotData AS pd
            ON
                p.MAC_ID = pd.MAC_ID
                AND pd.MerchantAmount < 0
        -----------------------------------------------------------------------------------------------------------

        -- Mark Missing Info of Mac_ID
        UPDATE bp
        SET BPStatusID = 2  --Missing Info
        --SELECT *
        FROM Billing.tblBillingPayments AS bp
        JOIN #PivotData AS pd
            ON pd.BillingPaymentID = bp.BillingPaymentID
        WHERE ISNULL(pd.MAC_ID, '') = '';
        -----------------------------------------------------------------------------------------------------------
        -- Remove missing (already marked) from temp table


        IF OBJECT_ID('tempdb..#Error') IS NOT NULL
            BEGIN
                DROP TABLE #Error;
            END;

        CREATE TABLE #Error
        (
            MAC_ID VARCHAR(50) NULL,
            WouldHaveBeenPaid DECIMAL(9, 2) NULL,
            ErrorMessage VARCHAR(200) NULL,
            XfinityFileName VARCHAR(50) NULL,
        );

        INSERT INTO #Error
        (
            MAC_ID,
            WouldHaveBeenPaid,
            ErrorMessage,
            XfinityFileName
        )

        SELECT
            p.MAC_ID,
            p.MerchantAmount AS WouldHaveBeenPaid,
            'Missing Mac ID' AS ErrorMessage,
            f.FileName
        --SELECT *
        FROM #PivotData AS p
        JOIN Billing.tblBillingPayments AS a
            ON
                a.BillingPaymentID = p.BillingPaymentID
                AND a.BPStatusID = 2
        JOIN billing.tblFiles AS f
            ON f.FileID = a.FileID

        DELETE p
        FROM #PivotData AS p
        WHERE
            EXISTS
            (
                SELECT 1
                FROM Billing.tblBillingPayments AS a
                WHERE
                    a.BillingPaymentID = p.BillingPaymentID
                    AND a.BPStatusID > 0
            );

        -----------------------------------------------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#OrderNo') IS NOT NULL
            BEGIN
                DROP TABLE #OrderNo;
            END;

        WITH
        Orders AS (
            SELECT
                b.BillingPaymentID
                , b.ParentCompanyID
                , b.MAC_ID
                , MAX(o.Order_No) AS [OOrderNo]
                , b.MerchantAmount
            FROM #PivotData AS b
            JOIN dbo.Orders AS o
                ON o.SKU = REPLACE(b.MAC_ID, ':', '')
            JOIN dbo.Order_No AS n
                ON n.Order_No = o.Order_No
            JOIN Products.tblProductCarrierMapping AS pcm
                ON o.Product_ID = pcm.ProductId
            JOIN dbo.Carrier_ID AS c
                ON
                    pcm.CarrierId = c.ID
                    AND c.ParentCompanyId = 8
            WHERE
                n.OrderType_ID IN (48, 49)
                AND n.Void = 0
                AND n.Filled = 1
                AND n.Process = 1
            GROUP BY
                b.BillingPaymentID
                , b.ParentCompanyID
                , b.MAC_ID
                , b.MerchantAmount
        )

        SELECT
            b.BillingPaymentID
            , b.ParentCompanyID
            , b.MAC_ID
            , CAST(n.Order_No AS VARCHAR(MAX)) AS [OOrderNo]
            , n.Account_ID
            , 10359 AS [ProductID] --MR20230523
            , b.MerchantAmount
        INTO #OrderNo
        FROM #PivotData AS b
        LEFT JOIN Orders AS o
            ON o.BillingPaymentID = b.BillingPaymentID
        LEFT JOIN dbo.Order_No AS n
            ON n.Order_No = o.OOrderNo;

        -----------------------------------------------------------------------------------------------------------
        -- Mark for missing orderNo or account_ID
        UPDATE bp
        SET BPStatusID = 3  --Cannot Locate Order
        --SELECT *
        FROM Billing.tblBillingPayments AS bp
        JOIN #OrderNo AS son
            ON son.BillingPaymentID = bp.BillingPaymentID
        WHERE
            son.OOrderNo IS NULL
            OR son.Account_ID IS NULL;

        INSERT INTO #Error
        (
            MAC_ID,
            WouldHaveBeenPaid,
            ErrorMessage,
            XfinityFileName
        )

        SELECT
            p.MAC_ID,
            p.MerchantAmount AS WouldHaveBeenPaid,
            'Cannot Locate Order' AS ErrorMessage,
            f.FileName
        FROM #PivotData AS p
        JOIN Billing.tblBillingPayments AS a
            ON
                a.BillingPaymentID = p.BillingPaymentID
                AND a.BPStatusID = 3
        JOIN billing.tblFiles AS f
            ON f.FileID = a.FileID


        -- Remove used from table
        DELETE p
        FROM #PivotData AS p
        WHERE
            EXISTS
            (
                SELECT 1
                FROM Billing.tblBillingPayments AS a
                WHERE
                    a.BillingPaymentID = p.BillingPaymentID
                    AND a.BPStatusID > 0
            );

        -----------------------------------------------------------------------------------------------------------
        -- get parent/child info (commission)
        IF OBJECT_ID('tempdb..#ListOfCommission') IS NOT NULL
            BEGIN
                DROP TABLE #ListOfCommission;
            END;

        WITH
        cte AS (
            SELECT
                t.OOrderNo
                , t.Account_ID AS [Merchant]
                , t.ProductID
                , t.MerchantAmount
                , f.ID AS [Child]
                , t.MAC_ID
            FROM #OrderNo AS t
            JOIN dbo.Account AS a
                ON a.Account_ID = t.Account_ID
            CROSS APPLY
                dbo.fnSplitter(
                    REPLACE(
                        RIGHT(LEFT(a.HierarchyString, LEN(a.HierarchyString) - 1), LEN(
                            LEFT(a.HierarchyString, LEN(
                                a.HierarchyString
                            )
                            - 1)
                        )
                        - 1)
                        , '/'
                        , ','
                    )
                ) AS f
            WHERE f.ID <> 2
        )
        SELECT
            t.OOrderNo AS [Order_No]
            , t.MAC_ID
            , t.Merchant
            , t.ProductID AS [Product_ID]
            , 0 AS [Price]
            , t.MerchantAmount
            , 0 AS [Base_Price]
            , achild.Account_ID AS [Child]
            , achild.DiscountClass_ID AS [ChildDC]
            , aparent.Account_ID AS [Parent]
            , aparent.DiscountClass_ID AS [ParentDC]
        INTO #ListOfCommission
        FROM cte AS t
        JOIN dbo.Account AS achild
            ON
                achild.Account_ID = t.Child
                AND t.Child <> 2
        JOIN dbo.Account AS aparent
            ON achild.ParentAccount_Account_ID = aparent.Account_ID;


        -----------------------------------------------------------------------------------------------------------
        -- find orders with commision amount
        IF OBJECT_ID('tempdb..#OrdersWithAmounts') IS NOT NULL
            BEGIN
                DROP TABLE #OrdersWithAmounts;
            END;

        SELECT
            t.Order_No
            , t.MAC_ID
            , t.Parent
            , t.MerchantAmount		--added
            , CASE
                WHEN dcpChild.Percent_Amount_Flg = 'P'
                    THEN
                        ROUND(
                            ((CASE
                                WHEN t.Merchant = t.Child THEN (t.Price - t.MerchantAmount)
                                ELSE
                                    (
                                        t.Price
                                        - (
                                            t.Price
                                            * ((
                                                dcpChild.Discount_Amt * dcpChild.ApprovedToSell_Flg
                                                * ISNULL(apdChild.ApprovedToSell_Flg, dcpChild.ApprovedToSell_Flg)
                                            ) / 100)
                                        )
                                    )
                            END)
                            - (
                                t.Price
                                - (
                                    t.Price
                                    * ((
                                        dcpParent.Discount_Amt * dcpParent.ApprovedToSell_Flg
                                        * ISNULL(apdParent.ApprovedToSell_Flg, dcpParent.ApprovedToSell_Flg)
                                    ) / 100)
                                )
                            ))
                            , 2
                        )
                ELSE
                    ROUND(
                        ((CASE
                            WHEN t.Merchant = t.Child THEN (t.Price - t.MerchantAmount)
                            ELSE
                                (
                                    t.Base_Price
                                    - (
                                        dcpChild.Discount_Amt * dcpChild.ApprovedToSell_Flg
                                        * ISNULL(apdChild.ApprovedToSell_Flg, dcpChild.ApprovedToSell_Flg)
                                    )
                                )
                        END)
                        - (
                            t.Base_Price
                            - (
                                dcpParent.Discount_Amt * dcpParent.ApprovedToSell_Flg
                                * ISNULL(apdParent.ApprovedToSell_Flg, dcpParent.ApprovedToSell_Flg)
                            )
                        ))
                        , 2
                    )
            END AS [CommissionAmount]
        INTO #OrdersWithAmounts
        FROM #ListOfCommission AS t
        JOIN dbo.DiscountClass_Products AS dcpChild
            ON
                t.ChildDC = dcpChild.DiscountClass_ID
                AND dcpChild.Product_ID = t.Product_ID
        LEFT JOIN dbo.Account_Products_Discount AS apdChild
            ON
                apdChild.Account_ID = t.Child
                AND apdChild.Product_ID = t.Product_ID
        JOIN dbo.DiscountClass_Products AS dcpParent
            ON
                t.ParentDC = dcpParent.DiscountClass_ID
                AND dcpParent.Product_ID = t.Product_ID
        LEFT JOIN dbo.Account_Products_Discount AS apdParent
            ON
                apdParent.Account_ID = t.Parent
                AND apdParent.Product_ID = t.Product_ID
        WHERE t.MerchantAmount > 0.00			--MR20230609


        INSERT INTO #OrdersWithAmounts			--MR20230609
        (
            Order_No,
            MAC_ID,
            Parent,
            MerchantAmount,
            [CommissionAmount]
        )

        SELECT
            t.Order_No
            , t.MAC_ID
            , t.Parent
            , t.MerchantAmount
            , (CASE
                WHEN dcpChild.Percent_Amount_Flg = 'P'
                    THEN
                        ROUND(
                            ((CASE
                                WHEN t.Merchant = t.Child THEN (t.Price - t.MerchantAmount)
                                ELSE
                                    (
                                        t.Price
                                        - (
                                            t.Price
                                            * ((
                                                dcpChild.Discount_Amt * dcpChild.ApprovedToSell_Flg
                                                * ISNULL(apdChild.ApprovedToSell_Flg, dcpChild.ApprovedToSell_Flg)
                                            ) / 100)
                                        )
                                    )
                            END)
                            - (
                                t.Price
                                - (
                                    t.Price
                                    * ((
                                        dcpParent.Discount_Amt * dcpParent.ApprovedToSell_Flg
                                        * ISNULL(apdParent.ApprovedToSell_Flg, dcpParent.ApprovedToSell_Flg)
                                    ) / 100)
                                )
                            ))
                            , 2
                        )
                ELSE
                    ROUND(
                        ((CASE
                            WHEN t.Merchant = t.Child THEN (t.Price - ABS(t.MerchantAmount))		--MR20230609
                            ELSE
                                (
                                    t.Base_Price
                                    - (
                                        dcpChild.Discount_Amt * dcpChild.ApprovedToSell_Flg
                                        * ISNULL(apdChild.ApprovedToSell_Flg, dcpChild.ApprovedToSell_Flg)
                                    )
                                )
                        END)
                        - (
                            t.Base_Price
                            - (
                                dcpParent.Discount_Amt * dcpParent.ApprovedToSell_Flg
                                * ISNULL(apdParent.ApprovedToSell_Flg, dcpParent.ApprovedToSell_Flg)
                            )
                        ))
                        , 2
                    )
            END) * -1 AS [CommissionAmount]
        FROM #ListOfCommission AS t
        JOIN dbo.DiscountClass_Products AS dcpChild
            ON
                t.ChildDC = dcpChild.DiscountClass_ID
                AND dcpChild.Product_ID = t.Product_ID
        LEFT JOIN dbo.Account_Products_Discount AS apdChild
            ON
                apdChild.Account_ID = t.Child
                AND apdChild.Product_ID = t.Product_ID
        JOIN dbo.DiscountClass_Products AS dcpParent
            ON
                t.ParentDC = dcpParent.DiscountClass_ID
                AND dcpParent.Product_ID = t.Product_ID
        LEFT JOIN dbo.Account_Products_Discount AS apdParent
            ON
                apdParent.Account_ID = t.Parent
                AND apdParent.Product_ID = t.Product_ID
        WHERE t.MerchantAmount < 0.00

        -----------------------------------------------------------------------------------------------------------
        --UPDATE bp
        --SET bp.BPStatusID = 10, --If missing from tblBPProductMapping
        --    bp.StatusUpdated = @getdate
        --FROM Billing.tblBillingPayments bp
        --    JOIN #MerchantAmount pd
        --        ON pd.BillingPaymentID = bp.BillingPaymentID
        --WHERE bp.BPStatusID = 0
        --      AND NOT EXISTS
        --(
        --    SELECT 1
        --    FROM Billing.tblBPProductMapping bppm
        --    WHERE bppm.BPProcessTypeID = bp.BPProcessTypeID
        --          AND bppm.CarrierID = 276
        --          AND bppm.ProductID IS NOT NULL
        --);

        --DELETE p
        --FROM #MerchantAmount p
        --WHERE EXISTS
        --(
        --    SELECT 1
        --    FROM Billing.tblBillingPayments a
        --    WHERE a.BillingPaymentID = p.BillingPaymentID
        --          AND a.BPStatusID > 0
        --);
        -----------------------------------------------------------------------------------------------------------
        -----------------------------------------------------------------------------------------------------------

        IF OBJECT_ID('tempdb..#MultipleProcessing') IS NOT NULL
            BEGIN
                DROP TABLE #MultipleProcessing;
            END;

        ; WITH CTE AS (
            SELECT
                pd.OOrderNo,
                pd.MAC_ID,
                pd.MerchantAmount,	--MR20230609
                COUNT(pd.BillingPaymentID) AS [Count]
            FROM #OrderNo AS pd
            WHERE pd.OOrderNo IS NOT NULL
            GROUP BY
                pd.OOrderNo,
                pd.MAC_ID,
                pd.MerchantAmount
            HAVING COUNT(pd.BillingPaymentID) > 1
        )
        SELECT MAX(bp.BillingPaymentID) AS BillingPaymentIDUpdate			--MR20230609
        INTO #MultipleProcessing
        FROM Billing.tblBillingPayments AS bp
        JOIN #OrderNo AS pd
            ON pd.BillingPaymentID = bp.BillingPaymentID
        JOIN CTE AS t
            ON
                t.OOrderNo = pd.OOrderNo
                AND t.MAC_ID = pd.MAC_ID
        WHERE bp.BPStatusID = 0;


        UPDATE bp
        SET
            bp.BPStatusID = 9, -- Multiple processing
            bp.StatusUpdated = @getdate
        FROM Billing.tblBillingPayments AS bp
        JOIN #MultipleProcessing AS mp
            ON mp.BillingPaymentIDUpdate = bp.BillingPaymentID
        WHERE
            bp.BPStatusID = 0
            AND mp.BillingPaymentIDUpdate IS NOT NULL

        INSERT INTO #Error
        (
            MAC_ID,
            WouldHaveBeenPaid,
            ErrorMessage,
            XfinityFileName
        )

        SELECT
            p.MAC_ID,
            p.MerchantAmount AS WouldHaveBeenPaid,
            'Multiple processing' AS ErrorMessage,
            f.FileName
        FROM #PivotData AS p
        JOIN Billing.tblBillingPayments AS a
            ON
                a.BillingPaymentID = p.BillingPaymentID
                AND a.BPStatusID = 9
        JOIN billing.tblFiles AS f
            ON f.FileID = a.FileID

        -----------------------------------------------------------------------------------------------------------
        --Check for already paid retro spiff
        UPDATE bp
        SET
            bp.BPStatusID = 4   -- Previously Processed
            , bp.StatusUpdated = @getdate
        FROM Billing.tblBillingPayments AS bp
        JOIN #OrderNo AS pd
            ON pd.BillingPaymentID = bp.BillingPaymentID
        WHERE
            bp.BPStatusID = 0
            AND EXISTS
            (
                SELECT 1
                FROM dbo.Order_No AS n
                JOIN dbo.Orders AS o1
                    ON
                        o1.Order_No = n.Order_No
                        AND ISNULL(o1.ParentItemID, 0) IN (0, 1)
                        AND o1.SKU = REPLACE(pd.MAC_ID, ':', '')

                WHERE
                    n.AuthNumber = pd.OOrderNo
                    AND n.OrderType_ID IN
                    (45, 46)
                    AND n.Filled = 1
                    AND n.Void = 0
                    AND o1.Price < 0
            );

        UPDATE bp			--MR20230609
        SET
            bp.BPStatusID = 4   -- Previously Processed
            , bp.StatusUpdated = @getdate
        --SELECT *
        FROM Billing.tblBillingPayments AS bp
        JOIN #OrderNo AS pd
            ON pd.BillingPaymentID = bp.BillingPaymentID
        WHERE
            EXISTS (
                SELECT 1 FROM Billing.tblBPData AS bpd
                JOIN billing.tblBPDataMapping AS dm
                    ON dm.BPDataID = bpd.BPDataID
                JOIN Billing.tblBillingPayments AS bp
                    ON
                        bp.BillingPaymentID = dm.BillingPaymentID
                        AND bp.BPStatusID = 1
                        --hardcoded due to this file Id was processed manually and didn't get the SKUs stamped with the MAC_ID.
                        AND bp.FileID = 2583
                WHERE
                    bpd.Data = pd.MAC_ID
                    AND bpd.DataType = 'MAC_ID'
            )
            AND bp.BPStatusID = 0

        INSERT INTO #Error
        (
            MAC_ID,
            WouldHaveBeenPaid,
            ErrorMessage,
            XfinityFileName
        )

        SELECT
            p.MAC_ID,
            p.MerchantAmount AS WouldHaveBeenPaid,
            'Retro Spiff Previously Paid' AS ErrorMessage,
            f.FileName
        FROM #PivotData AS p
        JOIN Billing.tblBillingPayments AS a
            ON
                a.BillingPaymentID = p.BillingPaymentID
                AND a.BPStatusID = 4
        JOIN billing.tblFiles AS f
            ON f.FileID = a.FileID

        -----------------------------------------------------------------------------------------------------------
        DELETE p
        FROM #OrderNo AS p
        WHERE
            EXISTS
            (
                SELECT 1
                FROM Billing.tblBillingPayments AS a
                WHERE
                    a.BillingPaymentID = p.BillingPaymentID
                    AND a.BPStatusID > 0
            );


        -----------------------------------------------------------------------------------------------------------
        --Check for instant spiff
        UPDATE bp
        SET
            bp.BPStatusID = 13  -- Previously Processed
            , bp.StatusUpdated = @getdate
        --SELECT *
        FROM Billing.tblBillingPayments AS bp
        JOIN #PivotData AS pd
            ON pd.BillingPaymentID = bp.BillingPaymentID
        WHERE
            bp.BPStatusID = 0
            AND EXISTS
            (
                SELECT 1
                FROM dbo.Order_No AS n
                JOIN dbo.Orders AS o1
                    ON
                        o1.Order_No = n.Order_No
                        AND o1.ParentItemID != 0
                        AND o1.Price < 0
                JOIN dbo.tblOrderItemAddons AS toia
                    ON
                        toia.OrderID = o1.ID
                        AND toia.AddonsValue = REPLACE(pd.MAC_ID, ':', '')
                WHERE
                    n.OrderType_ID IN
                    (22, 23)
                    AND n.Filled = 1
                    AND n.Process = 1
                    AND n.Void = 0
            );

        INSERT INTO #Error
        (
            MAC_ID,
            WouldHaveBeenPaid,
            ErrorMessage,
            XfinityFileName
        )

        SELECT
            p.MAC_ID,
            p.MerchantAmount AS WouldHaveBeenPaid,
            'Instant Spiff Previously Paid' AS ErrorMessage,
            f.FileName
        FROM #PivotData AS p
        JOIN Billing.tblBillingPayments AS a
            ON
                a.BillingPaymentID = p.BillingPaymentID
                AND a.BPStatusID = 13
        JOIN billing.tblFiles AS f
            ON f.FileID = a.FileID


        INSERT INTO #Error			--MR20240307
        (
            MAC_ID,
            WouldHaveBeenPaid,
            ErrorMessage,
            XfinityFileName
        )
        SELECT
            c.MAC_ID,
            c.TCETRASpiffAmount,
            'Not Reported by Xfinity' AS ErrorMessage,
            NULL AS XfinityFileName
        FROM OrderManagment.tblXfinityActivationReporting AS c
        JOIN dbo.order_no AS n
            ON n.Order_No = c.ActivationOrderNo
        WHERE
            n.DateFilled >= @StartDate
            AND n.DateFilled < @EndDate
            AND c.ActivationDateReportedFromXfinity IS NULL

        -----------------------------------------------------------------------------------------------------------
        DELETE p
        FROM #OrderNo AS p
        WHERE
            EXISTS
            (
                SELECT 1
                FROM Billing.tblBillingPayments AS a
                WHERE
                    a.BillingPaymentID = p.BillingPaymentID
                    AND a.BPStatusID > 0
            );

        -----------------------------------------------------------------------------------------------------------
        -----------------------------------------Begin Promo
        IF OBJECT_ID('tempdb..#Payout') IS NOT NULL
            BEGIN
                DROP TABLE #Payout;
            END;

        SELECT DISTINCT
            bp.BillingPaymentID
            , bp.BPProcessTypeID
            , a.Account_ID
            , a.Customer_ID
            , a.ShipTo
            , a.User_ID
            , IIF(a.AccountType_ID = 2, bppm.postpaidOrderType_id, bppm.prepaidOrderType_id) AS [OrderType_ID]
            , pd.OOrderNo AS [OrderNo]
            , a.CreditTerms_ID
            , a.DiscountClass_ID
            , pd.MerchantAmount AS [OrderTotal]
            , bppm.ProductID AS [ProductID]
            , bppm.ProductName AS [Name]
            , pd.MerchantAmount AS [Price]
            , pd.MAC_ID AS [SKU]
        INTO #Payout
        FROM Billing.tblBillingPayments AS bp
        JOIN #OrderNo AS pd
            ON pd.BillingPaymentID = bp.BillingPaymentID
        JOIN dbo.Account AS a
            ON a.Account_ID = pd.Account_ID
        JOIN [Billing].[tblBPProductMapping] AS bppm
            ON
                bppm.BPProcessTypeID = bp.BPProcessTypeID
                AND bppm.CarrierID = 276
                AND bppm.RefOrderType = 'Purchase'
        WHERE
            bp.BPStatusID = 0
            AND pd.merchantAmount <> 0.00;

        -----------------------------------------------------------------------------------------------------------
        UPDATE bp
        SET
            bp.BPStatusID = 8 --Missing Product
            , bp.StatusUpdated = @getdate
        FROM Billing.tblBillingPayments AS bp
        JOIN #Payout AS po
            ON po.BillingPaymentID = bp.BillingPaymentID
        WHERE
            bp.BPStatusID = 0
            AND
            (
                ISNULL(po.ProductID, 0) = 0
                OR ISNULL(po.Name, '') = ''
            );

        -------------------------------------------------------------------------------------------------------------
        DELETE p
        FROM #Payout AS p
        WHERE
            EXISTS
            (
                SELECT 1
                FROM Billing.tblBillingPayments AS a
                WHERE
                    a.BillingPaymentID = p.BillingPaymentID
                    AND a.BPStatusID > 0
            );

        -----------------------------------------------------------------------------------------------------------



        IF EXISTS (SELECT 1 FROM #Error)
            BEGIN
                DECLARE
                    @str_profile_name VARCHAR(100) = 'SQLAlerts'
                    , @str_from_address VARCHAR(100) = 'SqlAlerts@tcetra.com'
                    , @str_recipients VARCHAR(100) = 'mrios@tcetra.com; accounting@tcetra.com; bstahl@tcetra.com'
                    , @str_subject VARCHAR(100) = ('Xfinity Spiff Processing Issues')
                    , @xml NVARCHAR(MAX) =
                    CAST((
                        SELECT
                            e.ErrorMessage AS 'td', '', -- noqa: AL03
                            e.XfinityFileName AS 'td', '', -- noqa
                            e.MAC_ID AS 'td', '', -- noqa
                            e.WouldHaveBeenPaid AS 'td', '' -- noqa
                        FROM #Error AS e
                        ORDER BY e.ErrorMessage
                        FOR XML PATH ('tr'), ELEMENTS
                    )
                    AS VARCHAR(MAX))
                    , @str_body NVARCHAR(MAX) =
                    '<html><body>
				<H1>There were errors within a Xfinity Spiff file.</H1>
				<H3>Please see the table below for details. The following did not get processed.</H3>
				<table border = 1>
				<tr>
					<th>ErrorMessage</th>
					<th>XfinityFileName</th>
					<th>MAC_ID</th>
					<th>WouldHaveBeenPaid</th>
				</tr>'
                    , @xml2 NVARCHAR(MAX) =
                    CAST((

                        SELECT
                            MIN(CAST(n.DateFilled AS DATE)) AS 'td', '', -- noqa
                            MAX(CAST(N.DateFilled AS DATE)) AS 'td', '', -- noqa
                            COUNT(c.ActivationOrderNo) AS 'td', '', -- noqa
                            SUM(c.TCETRASpiffAmount) AS 'td', '', -- noqa
                            COUNT(c.ActivationDateReportedFromXfinity) AS 'td', '', -- noqa
                            ISNULL(SUM(c.xfinityAmount), 0.00) AS 'td', ''	-- noqa
                        FROM OrderManagment.tblXfinityActivationReporting AS c
                        JOIN dbo.order_no AS n
                            ON n.Order_No = c.ActivationOrderNo
                        WHERE
                            n.DateFilled >= @StartDate
                            AND n.DateFilled < @EndDate
                        FOR XML PATH ('tr'), ELEMENTS
                    )
                    AS VARCHAR(MAX))
                    , @str_body2 NVARCHAR(MAX) =
                    '<html><body>
						<table border = 1>
							<tr>
								<th> Start Date </th>
								<th> End Date </th>
								<th> Count of TCETRA activations </th>
								<th> SUM of TCETRA Instant Spiffs </th>
								<th> Count of Xfinity activations reported </th>
								<th> SUM of Xfinity Instant Spiffs reported</th>
							</tr>'
                SET
                    @str_body = @str_body + @xml + '</table></body></html>' + @str_body2 + @xml2 + '</table></body></html>'

                EXEC [msdb].[dbo].[sp_send_dbmail]
                    @profile_name = @str_profile_name
                    , @from_address = @str_from_address
                    , @recipients = @str_recipients
                    , @subject = @str_subject
                    , @body = @str_body
                    , @Body_format = 'HTML';
            END;



        -----------------------------------------------------------------------------------------------------------
        DECLARE @ToCreate ORDERFULLDETAILTBLWFLG;

        INSERT INTO @ToCreate
        (
            Account_ID
            , CustomerID
            , SHIPTO
            , USERID
            , OrderType_Id
            , RefOrderNo
            , DateDue
            , CreditTermID
            , DiscountClassID
            , DateFrom
            , DateFilled
            , OrderTotal
            , Process
            , Filled
            , Void
            , Product_ID
            , ProductName
            , SKU
            , PRICE
            , DiscAmount
            , FEE
            , Tracking
            , User_IPAddress
            , IsUnique
        )
        SELECT
            p.Account_ID
            , p.Customer_ID
            , p.ShipTo
            , p.User_ID
            , p.OrderType_ID
            , CAST(p.OrderNo AS VARCHAR(MAX)) AS [OrderNo]
            , dbo.fnCalculateDueDate(p.Account_ID, @getdate) AS [DateDue]
            , p.CreditTerms_ID
            , p.DiscountClass_ID
            , @getdate AS [DateFrom]    --p.DateOrdered AS DateFrom,
            , @getdate AS [DateFilled]
            , (p.OrderTotal * (-1)) AS [OrderTotal]
            , 1 AS [Process]
            , 1 AS [filled]
            , 0 AS [void]
            , p.ProductID
            , p.Name
            , p.SKU
            , (p.Price * (-1)) AS [Price]
            , 0 AS [DiscAmount]
            , 0 AS [Fee]
            , '192.168.151.9' AS [Tracking]
            , '192.168.151.9' AS [User_IPAddress]
            , 1 AS [IsUnique]
        FROM #Payout AS p;

        -----------------------------------------------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#return') IS NOT NULL
            BEGIN
                DROP TABLE #return;
            END;

        CREATE TABLE #return
        (
            ID INT
            , Order_No INT
        );

        INSERT INTO #return
        EXEC OrderManagment.P_OrderManagment_Build_Full_Order_table_wTracking_IP_inBatch
            @OrderDetail = @ToCreate    -- OrderFullDetailTblwFlg
            , @Batchsize = 1000;        -- int

        -----------------------------------------------------------------------------------------------------------

        UPDATE d
        SET d.Addons = d.SKU
        FROM dbo.orders AS d
        JOIN #return AS r
            ON r.ID = d.ID


        ; WITH
        X AS (
            SELECT
                o.Account_ID
                , SUM(ISNULL(o.OrderTotal, 0)) AS [TotalChange]
            FROM #return AS r
            JOIN dbo.Order_No AS o
                ON o.Order_No = r.Order_No
            GROUP BY o.Account_ID
        )
        UPDATE a
        SET
            AvailableTotalCreditLimit_Amt = a.AvailableTotalCreditLimit_Amt - X.TotalChange
            , AvailableDailyCreditLimit_Amt = a.AvailableDailyCreditLimit_Amt - X.TotalChange
        FROM dbo.Account AS a
        JOIN X
            ON X.Account_ID = a.Account_ID;

        -----------------------------------------------------------------------------------------------------------


        IF OBJECT_ID('tempdb..#finalProcessing') IS NOT NULL
            BEGIN
                DROP TABLE #finalProcessing;
            END;

        SELECT
            bp.BillingPaymentID
            , n.Order_No AS [NewOrder]
            , o.ID AS [NewOrderID]
            , n.OrderType_ID
            , bp.AccountID
            , p.OrderNo AS [OriginalOrderNo]
            , bp.ParentCompanyID
            , bp.BPProcessTypeID
            , pd.MAC_ID --added MR20230609
            , pd.MerchantAmount	--added MR20230609
        INTO #finalProcessing
        FROM Billing.tblBillingPayments AS bp
        JOIN #Payout AS p
            ON bp.BillingPaymentID = p.BillingPaymentID
        JOIN #PivotData AS pd
            ON p.BillingPaymentID = pd.BillingPaymentID
        JOIN dbo.Order_No AS n
            ON CAST(p.OrderNo AS NVARCHAR(50)) = n.AuthNumber
        JOIN #return AS r
            ON r.Order_No = n.Order_No
        JOIN dbo.Orders AS o
            ON
                r.ID = o.ID
                AND o.SKU = p.SKU
                AND o.Price = (pd.MerchantAmount * -1) --added MR20230609

        --SELECT *  FROM #finalProcessing

        -----------------------------------------------------------------------------------------------------------
        INSERT INTO Billing.tblBPPaymentOrder
        (BillingPaymentID, PaymentOrderNo)
        SELECT DISTINCT			--added distinct MR20230609
            f.BillingPaymentID
            , f.NewOrder
        FROM #finalProcessing AS f
        WHERE
            NOT EXISTS (
                SELECT 1 FROM billing.tblBPPaymentOrder AS po			--added MR20230609
                WHERE po.PaymentOrderNo = f.NewOrder
            )


        -----------------------------------------------------------------------------------------------------------
        INSERT INTO dbo.Order_Commission
        (Order_No, Orders_ID, Account_ID, Commission_Amt, Datedue, InvoiceNum)
        SELECT
            fp.NewOrder
            , fp.NewOrderID
            , t.Parent
            , CAST(ISNULL(t.CommissionAmount, 0) AS DECIMAL(7, 2)) AS [CommissionAmount]
            , dbo.fnCalculateDueDate(t.Parent, @getdate) AS [getdate]
            , NULL AS [NULL]
        --SELECT *
        FROM #OrdersWithAmounts AS t
        JOIN #finalProcessing AS fp
            ON
                t.Order_No = fp.OriginalOrderNo
                AND fp.MAC_ID = t.MAC_ID		--added to remove duplication MR20230609
                AND t.MerchantAmount = fp.MerchantAmount
        JOIN dbo.Orders AS o
            ON fp.NewOrderID = o.ID
        WHERE
            fp.OrderType_ID IN
            (45, 46);

        -----------------------------------------End Promo

        -----------------------------------------------------------------------------------------------------------

        DECLARE
            @FileName VARCHAR(50) = (			--MR20230609
                SELECT TOP (1) f.FileName
                FROM billing.tblBillingPayments AS bp
                JOIN #Payout AS po
                    ON po.BillingPaymentID = bp.BillingPaymentID
                JOIN billing.tblFiles AS f
                    ON f.FileID = bp.FileID
                WHERE bp.BPStatusID = 0
            )


        UPDATE bp
        SET
            bp.BPStatusID = 1
            , bp.StatusUpdated = @getdate
        FROM Billing.tblBillingPayments AS bp
        JOIN #Payout AS po
            ON po.BillingPaymentID = bp.BillingPaymentID
        WHERE bp.BPStatusID = 0;

        IF OBJECT_ID('tempdb..#SummedPayout') IS NOT NULL
            BEGIN
                DROP TABLE #SummedPayout;
            END;

        SELECT
            CAST(n.DateFilled AS DATE) AS DateFilled,
            d.Product_ID,
            d.Name,
            SUM(d.Price) AS SummedPayout,
            COUNT(d.Product_ID) AS PayoutCount,
            @FileName
                AS XfinityFileName
        INTO #SummedPayout							--MR20230609
        FROM dbo.Orders AS d
        JOIN dbo.Order_No AS n
            ON n.Order_No = d.Order_No
        JOIN #return AS r
            ON r.ID = d.ID
        GROUP BY
            n.DateFilled,
            d.Product_ID,
            d.Name


        IF OBJECT_ID('tempdb..#SummedCommission') IS NOT NULL
            BEGIN
                DROP TABLE #SummedCommission;
            END;

        SELECT
            SUM(oc.Commission_Amt) AS SummedCommissionPayout,
            oc.Account_ID,
            CAST(oc.Datedue AS DATE) AS DateDue
        INTO #SummedCommission						--MR20230609
        FROM dbo.Order_Commission AS oc
        JOIN #return AS r
            ON r.ID = oc.Orders_ID
        WHERE oc.Commission_Amt <> 0
        GROUP BY oc.Account_ID, CAST(oc.Datedue AS DATE)

        IF EXISTS (SELECT 1 FROM #SummedPayout)
            BEGIN
                DECLARE									--MR20230609
                    @str_name VARCHAR(100) = 'SQLAlerts'
                    , @str_address VARCHAR(100) = 'SqlAlerts@tcetra.com'
                    , @str_recipient VARCHAR(100) = 'mrios@tcetra.com; accounting@tcetra.com; bstahl@tcetra.com'
                    , @str_sub VARCHAR(100) = ('Xfinity Payout Summary')
                    , @xm NVARCHAR(MAX) =
                    CAST((
                        SELECT
                            s.Product_ID AS 'td', '' -- noqa
                            , s.Name AS 'td', '' -- noqa
                            , s.DateFilled AS 'td', '' -- noqa
                            , s.SummedPayout AS 'td', '' -- noqa
                            , s.PayoutCount AS 'td', '' -- noqa
                            , s.XfinityFileName AS 'td', '' -- noqa
                        FROM
                            #SummedPayout AS s
                        FOR XML PATH ('tr'), ELEMENTS
                    )
                    AS VARCHAR(MAX))
                    , @str NVARCHAR(MAX) =
                    '<html><body>
						<H1>Summary of Xfinity Payout file.</H1>
						<H3>Please see the table below for details.</H3>
						<table border = 1>
							<tr>
								<th> Product ID </th>
								<th> Name </th>
								<th> Date Filled </th>
								<th> Summed Payout </th>
								<th> Payout Count </th>
								<th> Xfinity File Name </th>
							</tr>'
                    , @xml22 NVARCHAR(MAX) =
                    CAST((
                        SELECT
                            c.Account_ID AS 'td', '' -- noqa
                            , c.SummedCommissionPayout AS 'td', '' -- noqa
                            , c.DateDue AS 'td', '' -- noqa
                        FROM
                            #SummedCommission AS c
                        FOR XML PATH ('tr'), ELEMENTS
                    )
                    AS VARCHAR(MAX))
                    , @str_body3 NVARCHAR(MAX) =
                    '<html><body>
						<table border = 1>
							<tr>
								<th> Account ID </th>
								<th> Summed Commission Payout </th>
								<th> Date Due </th>
							</tr>'
                SET
                    @str = @str + @xm + '</table></body></html>' + @str_body3 + @xml22 + '</table></body></html>'

                EXEC [msdb].[dbo].[sp_send_dbmail]
                    @profile_name = @str_name
                    , @from_address = @str_address
                    , @recipients = @str_recipient
                    , @subject = @str_sub
                    , @body = @str
                    , @Body_format = 'HTML'
            END;

        -- Cleanup
        DROP TABLE IF EXISTS #PivotData;
        DROP TABLE IF EXISTS #Error;
        DROP TABLE IF EXISTS #OrderNo;
        DROP TABLE IF EXISTS #return;
        DROP TABLE IF EXISTS #ListOfCommission;
        DROP TABLE IF EXISTS #OrdersWithAmounts;
        DROP TABLE IF EXISTS #MultipleProcessing;
        DROP TABLE IF EXISTS #Payout;
        DROP TABLE IF EXISTS #finalProcessing;

    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;
END;
-- noqa: disable=all
/
