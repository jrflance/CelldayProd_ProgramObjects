--liquibase formatted sql

--changeset MHoward:0D5553 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
-- =============================================
--             : 
--      Author : Olimpia
--             : 
--     Created : 2016-12-01
--             : 
-- Description : Processing Verizon Transaction Bill for Accounting team
--             : 
--       Usage : 
--             : 
--	MB20180411 : Added in #logData and #VendorData to add in proper mapping		
--			   :
-- MR20200317  : Added VendorDiscrepancy logic. Added UserName to CelldayTemp.tblVZWBill table
--			   :
-- MH20210304  : Added cost check
--			   :
-- MH20210415  : Added #Orders Insert for case when InvoiceNum from Datascape is not stamped as SKU
--			   :
-- MH20210430  : Updated cost check to account for 13006 and 13758 billed at face value and
--			   :	Promo Order that is billed together with Mobile Hotspot add on product
--			   :
-- MH20210922  : Updated Discrepancy insert to use NetCharges - Tcetra cost for Discrepancy Amount
--	   	       :		for Billed Incorrect Amount
--			   :
-- MH20211116  : Updated cost check to flag Incorrectly billed only if difference greater than .01
-- MH20211116  : Removed "TESTING ONLY" section
--			   :
-- MH20211117  : Fixed duplicate issue when more than one result in #HotSpot.
--			   :
-- MH20221213  : Added OrderType_ID 43 and 44
--			   :
-- MH20240215  : Removed ParentItemID filter for filtering out instant spiff
-- MH20240215  : Added new activation product mapping logic
-- =============================================
-- noqa: enable=all
CREATE OR ALTER PROCEDURE [Recon].[P_Upload_VZW_TransBillInfo]
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
        Id = 22;

    SET @Delimiter = ISNULL(@Delimiter, ',');

    TRUNCATE TABLE Celldaytemp.recon.tblVZWBill;

    INSERT INTO Celldaytemp.recon.tblVZWBill
    (
        BatchID,
        CtrlNum,
        DateIn,
        TimeIn,
        MTN,
        Denomination,
        AgentCommission,
        AgentSettlement,
        InvoiceNum,
        UserName
    )
    SELECT
        B.Chr1 AS BatchID,
        CAST(B.Chr2 AS INT) AS CtrlNum,
        CAST(LTRIM(RTRIM(B.Chr3)) AS DATE) AS DateIn,
        B.Chr4 AS TimeIn,
        B.Chr5 AS MTN,
        CONVERT( -- noqa: CV11
            DECIMAL(10, 4),
            CASE
                WHEN LEN(REPLACE(B.Chr6, '$', '')) = 0
                    THEN '0.00'
                ELSE REPLACE(REPLACE(REPLACE(REPLACE(B.Chr6, '$', ''), '(', ''), ')', ''), ',', '')
            END
        ) AS Denomination,
        CONVERT( -- noqa: CV11
            DECIMAL(10, 4),
            CASE
                WHEN LEN(REPLACE(B.Chr7, '$', '')) = 0
                    THEN '0.00'
                ELSE REPLACE(REPLACE(REPLACE(REPLACE(B.Chr7, '$', ''), '(', ''), ')', ''), ',', '')
            END
        ) AS AgentCommission,
        CONVERT( -- noqa: CV11
            DECIMAL(11, 4),
            CASE
                WHEN LEN(REPLACE(B.Chr8, '$', '')) = 0
                    THEN '0.00'
                ELSE REPLACE(REPLACE(REPLACE(REPLACE(B.Chr8, '$', ''), '(', ''), ')', ''), ',', '')
            END
        ) AS AgentSettlement,
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(B.Chr9, '$', ''), '(', ''), ')', ''), CHAR(10), ''), CHAR(13), ''), ',', '') AS InvoiceNum,
        B.Chr10 AS UserName
    FROM Recon.tblPlainText AS A
    CROSS APPLY Recon.fnEDITextParseByPass(@Delimiter, '"', NULL, LTRIM(RTRIM(A.PlainText)), 0) AS B
    WHERE ISNUMERIC(B.chr2) = 1;

    BEGIN TRY
        IF OBJECT_ID('tempdb..#CaseOne1') IS NOT NULL
            BEGIN
                DROP TABLE #CaseOne1;
            END;

        IF OBJECT_ID('tempdb..#CaseOne') IS NOT NULL
            BEGIN
                DROP TABLE #CaseOne;
            END;

        IF OBJECT_ID('tempdb..#Test') IS NOT NULL
            BEGIN
                DROP TABLE #Test;
            END;

        IF OBJECT_ID('tempdb..#Results') IS NOT NULL --MH20210415: added to make testing easier in the future
            BEGIN
                DROP TABLE #Results;
            END;

        IF OBJECT_ID('tempdb..#HotSpot') IS NOT NULL --MH20210430
            BEGIN
                DROP TABLE #HotSpot;
            END;

        --InvoiceNum stamped as SKU
        SELECT --ROW_NUMBER() OVER (PARTITION BY t.InvoiceNum ORDER BY n.DATEFILLED DESC) AS Rnum,		--MH20210415: moved to #CaseOne insert
            t.CtrlNum,
            n.Order_No,
            o.ID, --Added MB20180411
            n.Void,
            n.Filled,
            t.DateIn AS [Date],
            t.BatchID,
            t.MTN,
            o.product_ID, --Added MB20180411
            ISNULL(p.Product_Type, 0) AS Product_Type, --Added MB20180411
            n.datefilled, --Added MB20180411
            p.Vendor1_SKU, --Added MB20180411
            o.SKU,
            t.AgentSettlement,
            o.Price,
            t.InvoiceNum AS InvoiceNo,
            t.UserName,
            CASE --MH20210430 added case for 13006, 13758
                WHEN o.Product_ID IN (13006, 13758) AND o.Fee = 3
                    THEN o.Price
                ELSE
                    CASE -- noqa: ST04
                        WHEN dcp.Percent_Amount_Flg = 'P'
                            THEN ROUND(o.Price - (o.Price * (dcp.Discount_Amt / 100)), 2)
                        WHEN dcp.Percent_Amount_Flg = 'A'
                            THEN o.Price - dcp.Discount_Amt
                    END
            END AS TCetraAmtDue,
            n.OrderType_ID --MH20242015, added for new mapping logic
        INTO #CaseOne1
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No --AND ISNULL (o.ParentItemID, 0) = 0	--MH20240215, removed parent item ID
        JOIN recon.tblVZWBill AS t
            ON t.InvoiceNum = o.SKU
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID AND p.Product_Type IN (1, 2, 3) --MH20240215, added product_type
        JOIN dbo.DiscountClass_Products AS dcp --MH20210312
            ON o.Product_ID = dcp.Product_ID AND dcp.DiscountClass_ID = 10
        WHERE
            n.OrderType_ID IN (1, 9, 22, 23, 43, 44);

        --MH20221213 (added 43, 44)

        --InvoiceNum is our Order ID					 --MH20210415 this insert new
        INSERT INTO #CaseOne1
        (
            CtrlNum,
            Order_No,
            ID,
            Void,
            Filled,
            [Date],
            BatchID,
            MTN,
            Product_ID,
            Product_Type,
            DateFilled,
            Vendor1_SKU,
            SKU,
            AgentSettlement,
            Price,
            InvoiceNo,
            UserName,
            TCetraAmtDue,
            OrderType_ID
        )
        SELECT
            t.CtrlNum,
            n.Order_No,
            o.ID, --Added MB20180411
            n.Void,
            n.Filled,
            t.DateIn AS [Date],
            t.BatchID,
            t.MTN,
            o.product_ID, --Added MB20180411
            ISNULL(p.Product_Type, 0) AS Product_Type, --Added MB20180411
            n.datefilled, --Added MB20180411
            p.Vendor1_SKU, --Added MB20180411
            o.SKU,
            t.AgentSettlement,
            o.Price,
            t.InvoiceNum AS InvoiceNo,
            t.UserName,
            CASE --MH20210430 added case for 13006, 13758
                WHEN o.Product_ID IN (13006, 13758) AND o.Fee = 3
                    THEN o.Price
                ELSE
                    CASE -- noqa: ST04
                        WHEN dcp.Percent_Amount_Flg = 'P'
                            THEN ROUND(o.Price - (o.Price * (dcp.Discount_Amt / 100)), 2)
                        WHEN dcp.Percent_Amount_Flg = 'A'
                            THEN o.Price - dcp.Discount_Amt
                    END
            END AS TCetraAmtDue,
            n.OrderType_ID --MH20242015, added for new mapping logic
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No --AND ISNULL (o.ParentItemID, 0) = 0	--MH20240215, removed parent item ID
        JOIN recon.tblVZWBill AS t
            ON t.InvoiceNum = o.ID
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID AND p.Product_Type IN (1, 2, 3) --MH20240215, added product_type
        JOIN dbo.DiscountClass_Products AS dcp --MH20210312
            ON o.Product_ID = dcp.Product_ID AND dcp.DiscountClass_ID = 10
        JOIN Products.tblProductCarrierMapping AS pcm
            ON o.Product_ID = pcm.ProductId AND pcm.CarrierId = 7
        WHERE
            n.OrderType_ID IN (1, 9, 22, 23, 43, 44) --MH20221213 (added 43, 44)
            AND CAST(o.ID AS NVARCHAR) <> o.SKU
            AND t.[DateIn] = CAST(n.DateFilled AS DATE);

        --Gets Mobile HotSpot addons.  These are seperate Orders in Vidapay but billed with the activation			--MH20210430
        SELECT
            c1.Order_No,
            SUM( --MH20211117 added SUM
                CASE
                    WHEN dcp.Percent_Amount_Flg = 'P'
                        THEN ROUND(o.Price - (o.Price * (dcp.Discount_Amt / 100)), 2)
                    WHEN dcp.Percent_Amount_Flg = 'A'
                        THEN o.Price - dcp.Discount_Amt
                END
            ) AS AmtDue
        INTO #HotSpot
        FROM
            dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No AND o.ParentItemID = 1 --MH20240215.  Leaving this for now.
        JOIN dbo.Products AS p
            ON o.Product_ID = p.Product_ID AND p.Product_Type = 3
        JOIN dbo.DiscountClass_Products AS dcp
            ON o.Product_ID = dcp.Product_ID AND dcp.DiscountClass_ID = 10
        JOIN #CaseOne1 AS c1
            ON n.AuthNumber = c1.Order_No
        WHERE
            n.Filled = 1
            AND n.Process = 1
            AND n.Void = 0
        GROUP BY
            c1.Order_No; --MH20211117

        SELECT
            ROW_NUMBER() OVER (PARTITION BY co.InvoiceNo ORDER BY co.DATEFILLED DESC) AS Rnum, --MH20210415
            co.CtrlNum,
            co.Order_No,
            co.ID, --MH20210415		
            co.Void,
            co.Filled,
            co.[Date],
            co.BatchID,
            co.MTN,
            --CASE					--MH20240215 (removed)
            -- WHEN ISNULL(co.Product_Type, 0) = 3 THEN
            --             ISNULL(ISNULL(CAST(tvpm.VendorSkuBefore AS varchar(10)), CAST(vd.VendorSku AS varchar(10))), co.Product_ID)			
            --         ELSE
            --             co.Product_ID
            --     END AS [Product_ID], 
            p.Product_ID AS [Product_ID], --MH20240215
            co.SKU,
            co.AgentSettlement,
            co.Price,
            co.InvoiceNo,
            co.UserName,
            co.TCetraAmtDue --MH20210312
        INTO #CaseOne
        FROM
            #CaseOne1 AS co
        LEFT JOIN Orders.tblOrderVendorDetails AS vd --MH20240215
            ON co.ID = vd.OrderId AND co.OrderType_ID IN (22, 23)
        LEFT JOIN dbo.Vendor_Product_Mapping AS vpm
            ON co.Product_ID = vpm.Product_ID AND vpm.Region_ID = 1 AND co.OrderType_ID IN (22, 23)
        JOIN dbo.Products AS p
            ON
                CASE
                    WHEN co.OrderType_ID IN (22, 23) AND co.Product_Type = 3
                        THEN ISNULL(ISNULL(vd.FundingProductID, vpm.Vendor_SKU), co.Product_ID)
                    ELSE co.Product_ID
                END = p.Product_ID;

        -------------------------------------------------------END UPDATE ----------------------------------------------------------------
        SELECT
            co.BatchID,
            co.CtrlNum,
            co.MTN,
            co.InvoiceNo,
            CASE
                WHEN co.Product_ID <> co2.Product_ID
                    THEN -1
                WHEN co.Void = 0
                    THEN co.Order_No
                WHEN co.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(co2.Void, 1) = 1
                                THEN co.Order_No
                            WHEN ISNULL(co2.Void, -1) = 0
                                THEN co2.Order_No
                        END
                ELSE co.Order_No
            END AS Order_No,
            CASE --MH20210415
                WHEN co.Product_ID <> co2.Product_ID
                    THEN -1
                WHEN co.Void = 0
                    THEN co.ID
                WHEN co.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(co2.Void, 1) = 1
                                THEN co.ID
                            WHEN ISNULL(co2.Void, -1) = 0
                                THEN co2.ID
                        END
                ELSE co.ID
            END AS ID,
            CASE
                WHEN co.Product_ID <> co2.Product_ID
                    THEN -1
                WHEN co.Void = 0
                    THEN co.Void
                WHEN co.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(co2.Void, 1) = 1
                                THEN co.Void
                            WHEN ISNULL(co2.Void, -1) = 0
                                THEN co2.Void
                        END
                ELSE -1
            END AS Void,
            CASE
                WHEN co.Product_ID <> co2.Product_ID
                    THEN -1
                WHEN co.Void = 0
                    THEN co.Filled
                WHEN co.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(co2.Void, 1) = 1
                                THEN co.Filled
                            WHEN ISNULL(co2.Void, -1) = 0
                                THEN co2.Filled
                        END
                ELSE -1
            END AS Filled,
            CASE
                WHEN co.Void = 0
                    THEN co.Date
                WHEN co.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(co2.Void, 1) = 1
                                THEN co.Date
                            WHEN ISNULL(co2.Void, -1) = 0
                                THEN co2.Date
                        END
                ELSE co.Date
            END AS [Date],
            CASE
                WHEN co.Product_ID <> co2.Product_ID
                    THEN -1
                WHEN co.Void = 0
                    THEN co.Product_ID
                WHEN co.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(co2.Void, 1) = 1
                                THEN co.Product_ID
                            WHEN ISNULL(co2.Void, -1) = 0
                                THEN co2.Product_ID
                        END
                ELSE -1
            END AS Product_ID,
            CASE
                WHEN co.Void = 0
                    THEN co.SKU
                WHEN co.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(co2.Void, 1) = 1
                                THEN co.SKU
                            WHEN ISNULL(co2.Void, -1) = 0
                                THEN co2.SKU
                        END
                ELSE co.SKU
            END AS SKU,
            CASE
                WHEN co.Void = 0
                    THEN co.AgentSettlement
                WHEN co.Void = 1
                    THEN
                        CASE
                            WHEN ISNULL(co2.Void, 1) = 1
                                THEN co.AgentSettlement
                            WHEN ISNULL(co2.Void, -1) = 0
                                THEN co2.AgentSettlement
                        END
                ELSE co.AgentSettlement
            END AS Amount,
            CASE
                WHEN co.Product_ID <> ISNULL(co2.Product_ID, co.Product_ID)
                    THEN 'Error'
                WHEN co.Void = 1 AND co.Price < 0
                    THEN
                        CASE
                            WHEN ISNULL(co2.Void, 1) = 1
                                THEN 'Void'
                            WHEN ISNULL(co2.Filled, -1) = 0
                                THEN 'Pending'
                            WHEN co2.Price < 0
                                THEN 'Return'
                            --WHEN co2.AgentSettlement <> co2.TCetraAmtDue + ISNULL(h.AmtDue,0) THEN				--MH20210312, --MH20210430
                            WHEN ABS(co2.AgentSettlement - (co2.TCetraAmtDue + ISNULL(h.AmtDue, 0))) > .01
                                THEN 'Billed Incorrect Amt' --MH20210312, --MH20210430, --MH20211116
                            ELSE 'Success'
                        END
                ELSE
                    CASE -- noqa: ST04
                        WHEN co.Void = 1
                            THEN 'Void'
                        WHEN co.Filled = 0
                            THEN 'Pending'
                        WHEN co.Price < 0
                            THEN 'Return'
                        --WHEN co2.AgentSettlement <> co2.TCetraAmtDue + ISNULL(h.AmtDue,0) THEN				--MH20210312, --MH20210430
                        WHEN ABS(co2.AgentSettlement - (co2.TCetraAmtDue + ISNULL(h.AmtDue, 0))) > .01
                            THEN 'Billed Incorrect Amt' --MH20210312, --MH20210430, --MH20211116
                        WHEN co.Filled = 1
                            THEN 'Success'
                        ELSE 'Error'
                    END
            END AS [Status],
            co.UserName
        INTO #Test
        FROM #CaseOne AS co
        LEFT JOIN #CaseOne AS co2
            ON co.SKU = co2.SKU AND ISNULL(co2.Rnum, 0) = 2
        LEFT JOIN #HotSpot AS h --MH20210430
            ON co.Order_No = h.Order_No
        WHERE
            co.Rnum = 1;

        CREATE TABLE #Results
        (
            Order_No INT,
            void SMALLINT,
            Filled SMALLINT,
            CtrlNum VARCHAR(50),
            [Date] DATE,
            BatchID VARCHAR(20),
            MTN VARCHAR(20),
            AgentSettlement DECIMAL(9, 2),
            InvoiceNo VARCHAR(20),
            Product_ID INT,
            [Name] VARCHAR(50),
            --SKU VARCHAR(50),					--MH20210415
            SKU VARCHAR(100), --MH20210415
            Amount DECIMAL(9, 2),
            [Status] VARCHAR(20),
            UserName VARCHAR(50)
        )

        INSERT INTO #Results
        (
            Order_No,
            void,
            Filled,
            CtrlNum,
            [Date],
            BatchID,
            MTN,
            AgentSettlement,
            InvoiceNo,
            Product_ID,
            [Name],
            SKU,
            Amount,
            [Status],
            UserName
        )
        SELECT
            t.Order_No,
            t.Void,
            t.Filled,
            t.CtrlNum,
            t.Date,
            t.BatchID,
            t.MTN,
            t.Amount AS AgentSettlement,
            t.InvoiceNo,
            t.Product_ID,
            ISNULL(p.[NAME], '') AS [Name],
            t.SKU,
            t.Amount,
            t.[Status],
            t.UserName
        FROM #Test AS t
        LEFT JOIN dbo.Products AS p
            ON p.Product_ID = t.Product_ID
        UNION ALL
        SELECT
            -1 AS Order_No,
            0 AS Void,
            0 AS Filled,
            t.CtrlNum,
            t.DateIn AS [Date],
            t.BatchID,
            t.MTN,
            t.AgentSettlement,
            t.InvoiceNum AS InvoiceNo,
            -1 AS Product_ID,
            'ERROR' AS [Name],
            t2.SKU,
            t2.Amount,
            'Error' AS Status,
            t.UserName
        FROM Recon.tblVZWBill AS t
        LEFT JOIN #Test AS t2
            ON t2.SKU = t.InvoiceNum
        LEFT JOIN #Test AS t3 --MH20210415
            ON t3.ID = t.InvoiceNum
        WHERE
            t2.SKU IS NULL AND t3.ID IS NULL;

        --MH20210415

        --SELECT * FROM #Results		--TESTING ONLY, MH20211116
        TRUNCATE TABLE CelldayTemp.recon.tblVZWBillResult;

        INSERT INTO CelldayTemp.recon.tblVZWBillResult
        (
            Order_no,
            Void,
            Filled,
            CtrlNum,
            [Date],
            BatchID,
            MTN,
            AgentSettlement,
            InvoiceNo,
            Product_ID,
            [Name],
            SKU,
            Amount,
            [Status]
        )
        SELECT
            r.Order_No,
            r.void,
            r.Filled,
            r.CtrlNum,
            r.[Date],
            r.BatchID,
            r.MTN,
            r.AgentSettlement,
            r.InvoiceNo,
            r.Product_ID,
            r.[Name],
            r.SKU,
            r.Amount,
            r.[Status]
        FROM #Results AS r;

        INSERT INTO Cellday_Accounting.acct.VendorInvoice --MR20190711
        (
            InvoiceNo,
            InvoiceDate,
            Process_Id
        )
        SELECT DISTINCT
            CONCAT(YEAR(r.[Date]), MONTH(r.[Date]), DAY(r.[Date]), 'Datascape_VZN') AS InvoiceNo,
            r.[Date] AS InvoiceDate,
            1 AS Process_ID -- Datascape(VZN)
        FROM
            #Results AS r
        WHERE
            r.[Status] <> 'Success';

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
            1 AS process_ID, --Datascape(VZN)
            GETDATE() AS DateCreated,
            r.UserName AS UserCreated,
            CASE
                WHEN r.Status = 'Return'
                    THEN 17
                WHEN r.Status = 'Void'
                    THEN 9
                WHEN r.Status = 'Billed Incorrect Amt'
                    THEN 15 --MH20210312
                WHEN r.Status = 'Pending'
                    THEN 10
                ELSE 11
            END AS Discrepancy_ID,
            --r.AgentSettlement AS DiscrepancyAmt,								--MH20210922
            CASE
                WHEN r.Status = 'Billed Incorrect Amt'
                    THEN r.AgentSettlement - r.Amount
                ELSE r.AgentSettlement
            END AS DiscrepancyAmt,
            r.SKU AS TransactionID,
            r.Order_No AS Order_NO,
            vi.ID AS VendorInvoice_ID
        FROM
            #Results AS r
        JOIN Cellday_Accounting.acct.VendorInvoice AS vi
            ON vi.InvoiceDate = r.[Date] AND vi.Process_Id = 1 --Datascape(VZN)
        WHERE r.[Status] <> 'Success';
    END TRY
    BEGIN CATCH
        SELECT
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage;
    END CATCH;
END
-- noqa: disable=all
/