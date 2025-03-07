--liquibase formatted sql

--changeset MHoward:0D5550 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
/*=============================================
            : 
     Author : Olimpia
            : 
    Created : 2016-12-01
            : 
Description : Processing ISend Transaction Bill for Accounting team
            : 
      Usage : 
            : 
 MB20180413 : Added #logdata and #VendorData to map the product_IDs to match the invoice mapping	
			:
 MR20190711 : Added "Insert INTO Cellday_Accounting.acct.VendorInvoice" and "INSERT
			:		INTO Cellday_Accounting.acct.VendorDiscrepancies" sections.	
			:
 MR20200609 : Switched the t.SKU = o.SKU to CAST(t.SKU AS INT) = o.ID    
			: Switched mws.SKU to mws.TrxID in the ERROR Union section "Where not exist"
			:
 MR20200908 : Updated the varchar to MAX in the create #Results table section
			:
 MH20210226 : Added cost check
			:
 MH20210615 : Changed amount due in #Results to 4 decimal places to fix rounding issue and
			:	removed rounding from cost check
			:
 MH20210922 : Updated Discrepancy insert to use NetCharges - Tcetra cost for Discrepancy Amount
			:	for Billed Incorrect Amount
			:
 MH20211116 : Updated cost check to flag Incorrectly billed only if difference greater than .01
			:
 MH20240215 : Removed ParentItemID filter for excluding Spiffs to accomidate activation fee
 MH20240215 : Change to new mapping logic
=============================================*/
-- noqa: enable=all
CREATE OR ALTER PROCEDURE Recon.P_Upload_ISend_TransBillInfo
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    -- 1. insert txn
    DECLARE @Delimiter VARCHAR(16);

    SELECT
        @Delimiter = Delimiter
    FROM
        Recon.tblVendorSetup
    WHERE
        Id = 21;

    SET @Delimiter = ISNULL(@Delimiter, ',');

    TRUNCATE TABLE CellDayTemp.Recon.tblISendBill;

    INSERT INTO CellDayTemp.Recon.tblISendBill
    (
        SKU,
        DINGID,
        DestinationNum,
        Country,
        TransDATE,
        SendAmount,
        NetAmount,
        ReceiveAmount,
        UserName
    )
    SELECT
        B.Chr1 AS SKU,
        B.Chr2 AS DINGID,
        B.Chr3 AS DestinationNum,
        B.Chr4 AS Country,
        CONVERT(DATE, B.chr5) AS TransDate,
        CONVERT(
            DECIMAL(10, 4), CASE
                WHEN LEN(REPLACE(B.Chr6, '$', '')) = 0
                    THEN '0.00'
                ELSE REPLACE(REPLACE(REPLACE(REPLACE(B.Chr6, '$', ''), '(', ''), ')', ''), ',', '')
            END
        ) AS SendAmount,
        CONVERT(
            DECIMAL(10, 4), CASE
                WHEN LEN(REPLACE(B.Chr7, '$', '')) = 0
                    THEN '0.00'
                ELSE REPLACE(REPLACE(REPLACE(REPLACE(B.Chr7, '$', ''), '(', ''), ')', ''), ',', '')
            END
        ) AS NetAmount,
        CONVERT(
            DECIMAL(11, 4),
            CASE
                WHEN LEN(REPLACE(B.Chr8, '$', '')) = 0
                    THEN '0.00'
                ELSE REPLACE(
                    REPLACE(
                        REPLACE(REPLACE(REPLACE(REPLACE(B.Chr8, '$', ''), '(', ''), ')', ''), CHAR(10), ''),
                        CHAR(13), ''
                    ), ',', ''
                )
            END
        ) AS ReceiveAmount,
        B.Chr9
    FROM
        Recon.tblPlainText AS A
    CROSS APPLY Recon.fnEDITextParseByPass(@Delimiter, '"', NULL, LTRIM(RTRIM(A.PlainText)), 0) AS B
    WHERE ISDATE(B.Chr5) = 1;

    BEGIN TRY
        IF OBJECT_ID('tempdb..#MatchedSKU1') IS NOT NULL
            BEGIN
                DROP TABLE #MatchedSKU1;
            END;

        IF OBJECT_ID('tempdb..#MatchedSKU') IS NOT NULL
            BEGIN
                DROP TABLE #MatchedSKU;
            END;

        IF OBJECT_ID('tempdb..#MatchedWithStatus') IS NOT NULL
            BEGIN
                DROP TABLE #MatchedWithStatus;
            END;

        SELECT -- noqa: ST06
            ROW_NUMBER() OVER (
                PARTITION BY
                t.SKU
                ORDER BY n.DateFilled DESC
            ) AS Rnum,
            n.Order_No,
            n.Void,
            n.Filled,
            o.Product_ID,
            ISNULL(p.Product_Type, 0) AS Product_Type,
            o.ID,
            p.Vendor1_SKU,
            n.DateFilled,
            t.SKU AS TrxID,
            o.SKU,
            t.NetAmount,
            o.Price,
            CASE
                WHEN dcp.Percent_Amount_Flg = 'P'
                    THEN o.Price - (o.Price * (dcp.Discount_Amt / 100))
                WHEN dcp.Percent_Amount_Flg = 'A'
                    THEN o.Price - o.DiscAmount
            END AS TCetraCost, --MH20210226
            t.Country,
            t.TransDATE,
            t.UserName,
            n.OrderType_ID --MH20240215
        INTO
        #MatchedSKU1
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
            --AND ISNULL(o.ParentItemID, 0) = 0		--MH20240215 (removed)
        JOIN dbo.DiscountClass_Products AS dcp
            ON o.Product_ID = dcp.Product_ID AND dcp.DiscountClass_ID = 10
        JOIN CellDayTemp.Recon.tblISendBill AS t
            ON CAST(t.SKU AS INT) = o.ID -- noqa: CV11
        JOIN dbo.Products AS p
            ON
                p.Product_ID = o.Product_ID
                AND ISNULL(p.Product_Type, 0) IN (
                    0, 1, 2, 3
                ) --MH20240215
        WHERE
            n.OrderType_ID IN (
                1, 9, 22, 23
            );

        SELECT
            ms1.Rnum,
            ms1.Order_No,
            ms1.Void,
            ms1.Filled,

            -- CASE		--MH20240215 (removed)

            --WHEN ISNULL(ms1.Product_Type, 0) = 3 
            --THEN ISNULL(ISNULL(CAST(tvpm.VendorSkuBefore AS varchar(10)), CAST(vd.VendorSku AS varchar(10))), ms1.Product_ID)			
            --ELSE ms1.Product_ID
            -- END AS [Product_ID], 
            p.Product_ID, --MH20240215
            ms1.TrxID,
            ms1.SKU,
            ms1.NetAmount,
            ms1.Price,
            ms1.TCetraCost,
            ms1.Country,
            ms1.TransDATE,
            ms1.UserName
        INTO
        #MatchedSKU
        FROM #MatchedSKU1 AS ms1
        JOIN dbo.Products AS p2
            ON ms1.Product_ID = p2.Product_ID
        LEFT JOIN Orders.tblOrderVendorDetails AS vd
            ON
                ms1.ID = vd.OrderId
                AND ms1.OrderType_ID IN (
                    22, 23
                )
        LEFT JOIN dbo.Vendor_Product_Mapping AS vpm
            ON
                ms1.Product_ID = vpm.Product_ID
                AND vpm.Region_ID = 1
                AND ms1.OrderType_ID IN (
                    22, 23
                )
        JOIN dbo.Products AS p
            ON CASE
                WHEN ms1.OrderType_ID IN (22, 23) AND p2.Product_Type = 3
                    THEN ISNULL(ISNULL(vd.FundingProductId, vpm.Vendor_SKU), ms1.Product_ID)
                ELSE
                    ms1.Product_ID
            END = p.Product_ID;

        ------------------------------------------------------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#Test') IS NOT NULL
            BEGIN
                DROP TABLE #Test;
            END;

        SELECT -- noqa: ST06
            CASE
                WHEN ms.Product_ID <> ms2.Product_ID
                    THEN -1
                WHEN ms.Void = 0
                    THEN ms.Order_No
                WHEN ms.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(ms2.Void, 1) = 1
                                THEN ms.Order_No
                            WHEN ISNULL(ms2.Void, -1) = 0
                                THEN ms2.Order_No
                        END
                ELSE
                    ms.Order_No
            END AS Order_No,
            CASE
                WHEN ms.Product_ID <> ms2.Product_ID
                    THEN -1
                WHEN ms.Void = 0
                    THEN ms.Void
                WHEN ms.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(ms2.Void, 1) = 1
                                THEN ms.Void
                            WHEN ISNULL(ms2.Void, -1) = 0
                                THEN ms2.Void
                        END
                ELSE
                    -1
            END AS Void,
            CASE
                WHEN ms.Product_ID <> ms2.Product_ID
                    THEN -1
                WHEN ms.Void = 0
                    THEN ms.Filled
                WHEN ms.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(ms2.Void, 1) = 1
                                THEN ms.Filled
                            WHEN ISNULL(ms2.Void, -1) = 0
                                THEN ms2.Filled
                        END
                ELSE -1
            END AS Filled,
            CASE
                WHEN ms.Product_ID <> ms2.Product_ID
                    THEN -1
                WHEN ms.Void = 0
                    THEN ms.Product_ID
                WHEN ms.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(ms2.Void, 1) = 1
                                THEN ms.Product_ID
                            WHEN ISNULL(ms2.Void, -1) = 0
                                THEN ms2.Product_ID
                        END
                ELSE -1
            END AS Product_ID,
            ms.Country,
            ms.TrxID,
            CASE
                WHEN ms.Void = 0
                    THEN ms.SKU
                WHEN ms.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(ms2.Void, 1) = 1
                                THEN ms.SKU
                            WHEN ISNULL(ms2.Void, -1) = 0
                                THEN ms2.SKU
                        END
                ELSE ms.SKU
            END AS SKU,
            CASE
                WHEN ms.Void = 0
                    THEN ms.NetAmount
                WHEN ms.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(ms2.Void, 1) = 1
                                THEN ms.NetAmount
                            WHEN ISNULL(ms2.Void, -1) = 0
                                THEN ms2.NetAmount
                        END
                ELSE ms.NetAmount
            END AS Amount,
            ISNULL(ms.TCetraCost, 0) AS TCetraCost, --MH20210226
            CASE
                WHEN ms.Product_ID <> ISNULL(ms2.Product_ID, ms.Product_ID)
                    THEN 'Error'
                WHEN ms.Void = 1 AND ms.Price < 0
                    THEN
                        CASE
                            WHEN ISNULL(ms2.Void, 1) = 1
                                THEN 'Void'
                            WHEN ISNULL(ms2.Filled, -1) = 0
                                THEN 'Pending'
                            WHEN ms2.Price < 0
                                THEN 'Error'
                            --WHEN ms.TCetraCost <> ms.NetAmount THEN 'Billed Incorrect Amount'	--MH20210226, MH20210615, MH20211116
                            WHEN ABS(ms.TCetraCost - ms.NetAmount) > .01
                                THEN 'Billed Incorrect Amount' --MH20210226, MH20210615, MH20211116
                            ELSE 'Success'
                        END
                ELSE
                    CASE -- noqa: ST04
                        WHEN ms.Void = 1
                            THEN 'Void'
                        WHEN ms.Filled = 0
                            THEN 'Pending'
                        WHEN ms.Price < 0
                            THEN 'Error'
                        --WHEN ms.TCetraCost <> ms.NetAmount THEN 'Billed Incorrect Amount'			--MH20210226, MH20210615, MH20211116
                        WHEN ABS(ms.TCetraCost - ms.NetAmount) > .01
                            THEN 'Billed Incorrect Amount' --MH20210226, MH20210615, MH20211116
                        WHEN ms.Filled = 1
                            THEN 'Success'
                        ELSE 'Error'
                    END
            END AS Status,
            ms.TransDATE,
            ms.UserName
        INTO
        #MatchedWithStatus
        FROM #MatchedSKU AS ms
        LEFT JOIN #MatchedSKU AS ms2
            ON ms.SKU = ms2.SKU AND ISNULL(ms2.Rnum, 0) = 2
        WHERE
            ms.Rnum = 1;

        -------
        IF OBJECT_ID('tempdb..#Results') IS NOT NULL
            BEGIN
                DROP TABLE #Results;
            END;

        CREATE TABLE #Results
        (
            Order_No INT,
            void SMALLINT,
            Filled SMALLINT,
            Product_ID INT,
            [Name] VARCHAR(MAX),
            TrxID VARCHAR(MAX),
            SKU VARCHAR(MAX),
            Amount DECIMAL(10, 4), --MH20210615
            TCetraCost DECIMAL(10, 4), --MH20210226, MH20210615
            [Status] VARCHAR(MAX),
            Country VARCHAR(MAX),
            TransDate DATETIME,
            UserName VARCHAR(MAX)
        );

        INSERT INTO #Results
        (
            Order_No,
            void,
            Filled,
            Product_ID,
            [Name],
            TrxID,
            SKU,
            Amount,
            TCetraCost, --MH20210226
            [Status],
            Country,
            TransDate,
            UserName
        )
        SELECT
            t.Order_No,
            t.Void,
            t.Filled,
            t.Product_ID,
            ISNULL(p.Name, '') AS [Name],
            t.TrxID,
            t.SKU,
            t.Amount,
            t.TCetraCost, --MH20210226
            t.[Status],
            t.Country,
            t.TransDATE,
            t.UserName
        FROM #MatchedWithStatus AS t
        LEFT JOIN dbo.Products AS p
            ON p.Product_ID = t.Product_ID
        UNION ALL
        SELECT
            -1 AS Order_No,
            0 AS Void,
            0 AS Filled,
            -1 AS Product_ID,
            'ERROR' AS [Name],
            t.SKU AS TrxID,
            '0' AS SKU,
            t.NetAmount AS Amount,
            -1 AS TCetraCost, --MH20210226
            'ERROR' AS Status,
            t.Country,
            t.TransDATE,
            t.UserName
        FROM
            CellDayTemp.Recon.tblISendBill AS t
        WHERE
            NOT EXISTS
            (
                SELECT
                    1
                FROM
                    #MatchedWithStatus AS mws
                WHERE
                    mws.TrxID = t.SKU
            )
        ORDER BY
            [Status],
            SKU;

        TRUNCATE TABLE CellDayTemp.Recon.tblISendBillResult;

        INSERT INTO CellDayTemp.Recon.tblISendBillResult
        (
            Order_no,
            Void,
            Filled,
            Product_ID,
            [Name],
            TrxID,
            SKU,
            Amount,
            TCetraCost, --MH20210226
            [Status],
            Country
        )
        SELECT
            r.Order_No,
            r.void,
            r.Filled,
            r.Product_ID,
            r.[Name],
            r.TrxID,
            r.SKU,
            r.Amount,
            r.TCetraCost, --MH20210226
            r.[Status],
            r.Country
        FROM
            #Results AS r;

        INSERT INTO Cellday_Accounting.acct.VendorInvoice --MR20190711
        (
            InvoiceNo,
            InvoiceDate,
            Process_Id
        )
        SELECT DISTINCT
            CONCAT(YEAR(r.TransDate), MONTH(r.TransDate), DAY(r.TransDate), 'iSend_DING') AS InvoiceNo,
            r.TransDate AS InvoiceDate,
            3 AS Process_ID -- iSend(DING)
        FROM
            #Results AS r
        WHERE
            r.Status <> 'Success';

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
            3 AS process_ID, --iSend(DING)
            GETDATE() AS DateCreated,
            CURRENT_USER AS UserCreated,
            CASE
                WHEN r.Status = 'Void'
                    THEN 9
                WHEN r.Status = 'Pending'
                    THEN 10
                WHEN r.Status = 'Billed Incorrect Amount'
                    THEN 15 --MH20210226
                ELSE 11
            END AS Discrepancy_ID,
            --r.Amount AS DiscrepancyAmt ,										--MH20210922
            CASE
                WHEN r.Status = 'Billed Incorrect Amount'
                    THEN
                        r.Amount - r.TCetraCost
                ELSE
                    r.Amount
            END AS DiscrepancyAmt,
            r.TrxID AS TransactionID,
            r.Order_No AS Order_NO,
            vi.ID AS VendorInvoice_ID
        FROM
            #Results AS r
        JOIN Cellday_Accounting.acct.VendorInvoice AS vi
            ON
                vi.InvoiceDate = r.TransDate
                AND vi.Process_Id = 3 --iSend(DING)
        WHERE
            r.Status <> 'Success';
    END TRY
    BEGIN CATCH
        SELECT
            ERROR_NUMBER() AS ERR_NO,
            ERROR_MESSAGE() AS ERR_MSG;
    END CATCH;
END
-- noqa: disable=all
/